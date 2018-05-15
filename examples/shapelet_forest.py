import numpy as np
import time

from sklearn.ensemble import BaggingClassifier
# from sklearn.ensemble.weight_boosting import AdaBoostClassifier
# from sklearn.model_selection import cross_val_score
# from sklearn.tree import DecisionTreeClassifier

from wildboar.tree import ShapeletTreeClassifier
from wildboar._utils import print_tree


def testit():
    train = np.loadtxt("synthetic_control_TRAIN")
    test = np.loadtxt("synthetic_control_TEST")

    y = train[:, 0].astype(np.intp)
    x = train[:, 1:].astype(np.float64)
    tree = ShapeletTreeClassifier(n_shapelets=100, max_depth=None)
    tree.fit(x, y)
    tree.score(test[:, 0], train[:, 1:])


if __name__ == "__main__":

    x = [
        [0, 0, 1, 10, 1],
        [0, 0, 1, 10, 1],
        [0, 1, 9, 1, 0],
        [1, 9, 1, 0, 0],
        [0, 1, 9, 1, 0],
        [0, 1, 2, 3, 4],
        [1, 2, 3, 0, 0],
        [0, 0, 0, 1, 2],
        [0, 0, -1, 0, 1],
        [1, 2, 3, 0, 1],
    ]
    x = np.array(x, dtype=np.float64)
    x = np.hstack([x, x]).reshape(-1, 2, x.shape[-1])
    y = np.array([0, 0, 0, 0, 0, 1, 1, 1, 1, 1])

    random_state = np.random.RandomState(123)
    order = np.arange(10)
    random_state.shuffle(order)

    x = x[order, :]
    y = y[order]

    print(x)
    print(y)

    tree = ShapeletTreeClassifier(random_state=10, metric="scaled_dtw")
    tree.fit(x, y, sample_weight=np.ones(x.shape[0]) / x.shape[0])
    print_tree(tree.root_node_)

    print("Score")
    print(tree.score(x, y))
    print("score_done")

    train = np.loadtxt("data/synthetic_control_TRAIN", delimiter=",")
    test = np.loadtxt("data/synthetic_control_TEST", delimiter=",")

    y = train[:, 0].astype(np.intp)
    x = train[:, 1:].astype(np.float64)
    i = np.arange(x.shape[0])

    np.random.shuffle(i)

    x_test = test[:, 1:].astype(np.float64)
    y_test = test[:, 0].astype(np.intp)

    tree = ShapeletTreeClassifier(
        n_shapelets=10,
        max_depth=None,
        metric='scaled_dtw',
        min_shapelet_size=0.1,
        max_shapelet_size=1,
        metric_params={"r": 3})

    bag = BaggingClassifier(
        base_estimator=tree,
        bootstrap=True,
        n_jobs=16,
        n_estimators=100,
        random_state=100,
    )

    c = time.time()
    bag.fit(x, y)
    print(bag.classes_)
    print("acc:", bag.score(x_test, y_test))
    print(round(time.time() - c) * 1000)